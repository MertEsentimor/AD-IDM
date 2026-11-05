# Geliştirme aracı: V1'den taşınan XAML'deki sabit renkleri V2 tema adlarına çevirir. Uygulama çalışırken kullanılmaz.
# Kullanım: .\Tools\Convert-V1XamlColor.ps1 -Path .\UI\Dialogs\NewUser.xaml
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Path)

$colorTokens = @{
    Background = @{
        '#F3F3F3' = 'CanvasBrush'; '#FFFFFF' = 'SurfaceBrush'; 'White' = 'SurfaceBrush'
        '#F9F9F9' = 'SurfaceSubtleBrush'; '#FBFBFB' = 'SurfaceSubtleBrush'; '#F6F6F6' = 'SurfaceSubtleBrush'
        '#F0F0F0' = 'SurfaceHoverBrush'; '#F5F5F5' = 'SurfaceHoverBrush'; '#EBEBEB' = 'SurfaceHoverBrush'; '#E5E5E5' = 'SurfacePressedBrush'
        '#005FB8' = 'AccentBrush'; '#C42B1C' = 'DangerBrush'; '#0F7B0F' = 'SuccessBrush'; '#9D5D00' = 'WarningBrush'
        '#FDE7E9' = 'DangerBgBrush'; '#FFF4CE' = 'WarningBgBrush'; '#FFF8EC' = 'WarningBgBrush'; '#DFF6DD' = 'SuccessBgBrush'; '#EFF6FC' = 'InfoBgBrush'
    }
    Foreground = @{
        '#1B1B1B' = 'TextBrush'; '#616161' = 'TextMutedBrush'; '#6B6B6B' = 'TextMutedBrush'; '#8A8A8A' = 'TextMutedBrush'
        '#005FB8' = 'AccentTextBrush'; '#FFFFFF' = 'OnAccentBrush'; 'White' = 'OnAccentBrush'
        '#0F7B0F' = 'SuccessBrush'; '#9D5D00' = 'WarningBrush'; '#C42B1C' = 'DangerBrush'
    }
    BorderBrush = @{
        '#E5E5E5' = 'LineBrush'; '#EBEBEB' = 'LineSubtleBrush'; '#8A8A8A' = 'ControlLineBrush'
        '#005FB8' = 'AccentTextBrush'; '#0F7B0F' = 'SuccessBrush'; '#9D5D00' = 'WarningBrush'; '#C42B1C' = 'DangerBrush'
    }
    Fill = @{
        '#E5E5E5' = 'LineBrush'; '#EBEBEB' = 'LineSubtleBrush'; '#8A8A8A' = 'StatusNeutralBrush'; '#005FB8' = 'AccentBrush'
        '#0F7B0F' = 'SuccessBrush'; '#9D5D00' = 'WarningBrush'; '#C42B1C' = 'DangerBrush'; '#D9822B' = 'WarningBrush'; 'White' = 'OnAccentBrush'; '#FFFFFF' = 'OnAccentBrush'
    }
}
$text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
$unknownColors = New-Object -TypeName 'System.Collections.Generic.List[string]'
$converted = [regex]::Replace($text, '(?<![\w.:])(Background|Foreground|BorderBrush|Fill|Stroke)="(#[0-9A-Fa-f]{6,8}|White|Black)"', {
        param($match)
        $property = $match.Groups[1].Value
        $color = $match.Groups[2].Value
        $map = $colorTokens[$(if ($property -eq 'Stroke') { 'BorderBrush' } else { $property })]
        $token = $map[$(if ($color -like '#*') { $color.ToUpperInvariant() } else { $color })]
        if (-not $token) { $unknownColors.Add($match.Value); return $match.Value }
        return ('{0}="{{DynamicResource {1}}}"' -f $property, $token)
    })
$converted = [regex]::Replace($converted, 'Property="(Background|Foreground|BorderBrush|Fill|Stroke)" Value="(#[0-9A-Fa-f]{6,8}|White|Black)"', {
        param($match)
        $property = $match.Groups[1].Value
        $color = $match.Groups[2].Value
        $map = $colorTokens[$(if ($property -eq 'Stroke') { 'BorderBrush' } else { $property })]
        $token = $map[$(if ($color -like '#*') { $color.ToUpperInvariant() } else { $color })]
        if (-not $token) { $unknownColors.Add($match.Value); return $match.Value }
        return ('Property="{0}" Value="{{DynamicResource {1}}}"' -f $property, $token)
    })
if ($unknownColors.Count -gt 0) { throw "Eşlenmeyen renkler: $(($unknownColors | Select-Object -Unique) -join ', ')" }
[System.IO.File]::WriteAllText($Path, $converted, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
